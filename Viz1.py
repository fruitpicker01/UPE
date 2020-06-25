import wx


class MainPanel(wx.Panel):

    def __init__(self, parent):
        wx.Panel.__init__(self, parent=parent)
        self.frame = parent
        sizer = wx.BoxSizer(wx.VERTICAL)
        hSizer = wx.BoxSizer(wx.HORIZONTAL)

        label = "85,2 кВт"
        btn = wx.Button(self, label=label)
        sizer.Add(btn, 0, wx.ALL, 5)
        hSizer.Add((1, 1), 1, wx.EXPAND)
        hSizer.Add(sizer, 0, wx.TOP, 180)
        hSizer.Add((1, 1), 0, wx.ALL, 120)
        self.SetSizer(hSizer)
        self.Bind(wx.EVT_ERASE_BACKGROUND, self.OnEraseBackground)

    def OnEraseBackground(self, evt):
        dc = evt.GetDC()
        if not dc:
            dc = wx.ClientDC(self)
            rect = self.GetUpdateRegion().GetBox()
            dc.SetClippingRect(rect)

        dc.Clear()
        bmp = wx.Bitmap("kgis2199.jpg")
        dc.DrawBitmap(bmp, 0, 0)


class MainFrame(wx.Frame):

    def __init__(self):
        wx.Frame.__init__(self, None, size=(810, 530))
        panel = MainPanel(self)
        self.Center()


class Main(wx.App):

    def __init__(self, redirect=False, filename=None):
        wx.App.__init__(self, redirect, filename)
        dlg = MainFrame()
        dlg.Show()


if __name__ == "__main__":
    app = Main()
    app.MainLoop()